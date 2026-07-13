# Conveyor (cross-platform application packaging and updates)

A proprietary application packager/updater with an open-source guide, Gradle metadata
plugin, and GitHub Action that generates native installers, update repositories, and
publication-ready download sites from prebuilt application inputs.

| Field             | Value                                                                                                                                                                                              |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Languages         | Proprietary core; Kotlin OSS Gradle plugin; YAML/shell OSS GitHub Action; checked-in Markdown documentation                                                                                        |
| License           | **Mixed:** Apache-2.0 for this repository; the Conveyor packaging engine is proprietary                                                                                                            |
| Repository        | [hydraulic-software/conveyor][repo]                                                                                                                                                                |
| Documentation     | [Conveyor user guide][docs]                                                                                                                                                                        |
| Reviewed revision | [`9e90ce7c2a4356c99d68c63f41e4bc497da279c8`][revision] (`v22.0`)                                                                                                                                   |
| Category          | **Application packager/updater with publication adapters**; not a general release control plane                                                                                                    |
| Supported hosts   | Conveyor documents packaging all desktop targets from Linux, macOS, or Windows; the checked-in GitHub Action itself is Linux x64-only                                                              |
| Desktop targets   | Windows x64/Arm64; macOS Intel/Apple Silicon; Linux glibc x64/Arm64 plus musl inputs                                                                                                               |
| OSS/paid boundary | Guide, Gradle plugin, and Action source are OSS; the package/sign/update engine is not present in the repository; OSS projects may use it free, proprietary projects require a per-project license |

**Last reviewed:** July 12, 2026

> [!IMPORTANT]
> **Evidence boundary:** `[source-verified]` below means verified in the pinned OSS
> repository—usually its checked-in product guide, plugin, tests, or workflows. The
> repository says it contains only “the parts of the product that are open source”
> ([`README.md`][readme]); the commercial core cannot be implementation-audited here.
> Product mechanics are therefore documentation-verified, not independently
> source-verified or host-verified. The downloaded core is EULA-gated even though this
> repository is Apache-2.0. No package was built in this review.

## Overview

### What it solves

Conveyor consumes already-built native, Electron, Flutter, or JVM application files and
turns them into native desktop layouts, installers, update metadata, a download site,
and—when configured—uploaded releases. Its positioning is explicit
([`guidebook/docs/index.md`][guide-index]):

> “Conveyor makes distributing desktop apps as easy as shipping a web app.”

The default `site` task fans out across platforms, signing and notarizing as configured,
and assembles the packages and metadata clients use for future updates. That is broader
than a format backend, but narrower than a general release control plane: Conveyor does
not plan source versions, compile arbitrary target binaries, run tests, generate release
notes, or coordinate an organization-wide promotion process. Target compilation remains
upstream; package/update-site generation and selected upload operations are its scope.

### Design philosophy

Three choices define the product:

1. **Native formats and native update authorities.** Windows uses MSIX/App Installer,
   macOS embeds Sparkle, and Debian packages participate in APT rather than sharing a
   proprietary updater format ([`package-formats.md`][formats]).
2. **Cross-packaging instead of a mandatory native-runner matrix.** The guide claims
   Windows and macOS signing/notarization can run from Linux, and CI examples use one
   Conveyor job after target binaries have been produced elsewhere
   ([`continuous-integration.md`][ci]). This is a distinct commercial capability; its
   implementation is absent from the OSS tree.
3. **A declarative task DAG with caching.** A HOCON configuration supplies inputs and
   metadata; tasks materialize intermediate trees in a content-addressed cache and copy
   requested results to the output directory ([`running.md`][running],
   [`performance.md`][performance]).

The OSS Gradle plugin is only a metadata bridge. Its documentation says it “extracts
settings from a build and emits a Conveyor config snippet”
([`gradle-plugin/README.md`][gradle-readme]);
`ConveyorGradlePlugin` registers `printConveyorConfig` and `writeConveyorConfig`, while
`ConveyorConfigTask` maps Gradle/JVM/Compose/JavaFX state into HOCON
([`ConveyorGradlePlugin.kt`][gradle-plugin], [`ConveyorConfigTask.kt`][gradle-task]). It
does not package an application itself.

## How it works

A minimal native configuration names versioned, machine-specific inputs and the update
site:

```hocon
app {
  display-name = "Example App"
  fsname = example-app
  version = 1.1
  site.base-url = downloads.example.com/example-app
  inputs += example-app-1.1.zip
}
```

The input filename can provide the filesystem name and version; explicit
`app.<machine>.inputs` entries override or extend the hierarchy. URLs, local files,
directories, archives, inline content, globs, remapping, and optional inputs are
supported ([`inputs.md`][inputs]). Typical task boundaries are:

```bash
conveyor make app
conveyor make windows-msix
conveyor -Kapp.machines=mac.aarch64 make notarized-mac-zip
conveyor make debian-package
conveyor make site
conveyor make copied-site
```

`make site` constructs packages, update metadata, and static download UI;
`copied-site` additionally publishes to the configured destination. Individual target
tasks expose intermediate products for inspection. `task-dependencies site` displays
the DAG ([`running.md`][running]).

## Packaging analysis

### Input and staging

`[source-verified]` Inputs are payload files, not source-build declarations. Native
inputs become the installation directory on Windows, the inside of `Contents` on macOS,
and the vendor application directory on Linux. Electron and JVM inputs are placed in
framework-specific subtrees. Machine names combine OS, CPU, and Linux libc, allowing
common and target-specific files in one configuration ([`inputs.md`][inputs]).

Archives are extracted by default, URL inputs are downloaded, and mapping rules can move
or drop content. External symlinks are followed so packages remain hermetic; internal
symlinks may remain links. Tasks work in independent cache entries rather than mutating
the source tree, then copy final trees to `--output-dir` ([`performance.md`][performance]).

The Gradle plugin can derive `app.version`, `app.rdns-name`, main class, JVM arguments,
JDK vendor/version, and platform-specific dependencies. It synchronizes build metadata;
it does not change the fundamental requirement to provide already-compiled target
inputs ([`gradle-plugin/README.md`][gradle-readme]).

### Outputs and target matrix

`[source-verified]` The documented desktop outputs are:

| Platform | Primary package/update path                                                                            | Alternate output                            |
| -------- | ------------------------------------------------------------------------------------------------------ | ------------------------------------------- |
| Windows  | Signed `.msix`, `.appinstaller`, and a small installer `.exe`                                          | Plain `.zip` without automatic updates      |
| macOS    | Signed/notarized `.app` inside per-architecture `.zip`, Sparkle `appcast.rss`, optional `.delta` files | Unpackaged `.app`; **no DMG output**        |
| Linux    | `.deb` plus an APT repository                                                                          | Generic `.tar.gz` without automatic updates |

Conveyor also emits download/install scripts, self-signing certificates when applicable,
`metadata.properties`, and a static download page ([`package-formats.md`][formats]). It
does not currently produce RPM, AppImage, Flatpak, Snap, MSI, NSIS, DMG, PKG, or Mac
App Store artifacts; these absences matter when comparing apparent “all-platform”
coverage.

The **packaging host need not match the target** according to the product guide. A Linux
worker can produce and sign all listed formats, including Apple notarization. Target
binaries are a separate matter: native applications still need compatible executables
for every requested machine, commonly supplied by an upstream native/cross-compile CI
matrix. This cross-packaging claim belongs to the proprietary core and was not
host-verified in this review. Some checked-in pages disagree about Arm availability and
minimum Windows versions; the metadata table follows the version-22 target list, but
those targets require binary validation before adoption.

### Metadata and dependencies

`[source-verified]` Shared configuration covers identity, display/filesystem names,
version plus integer revision, vendor/contact, reverse-DNS identifier, icons, file/URL
associations, launchers, machines, and inputs. More than 120 target-specific settings
expose MSIX manifests, macOS plist/Sparkle options, Debian control fields/scripts,
service definitions, JVM linking, Electron ASAR, and native layouts
([`guidebook/docs/index.md`][guide-index]).

Dependency semantics remain format-specific. JVM inputs can include a `jlink`-reduced
runtime; Electron dependencies can be pruned; Debian declares and can derive `Depends`
from shared-library inspection; generic tarballs vendor only supplied files. Conveyor
does not expose one cross-platform dependency solver. `app.version` and numeric
`app.revision` are translated to platform rules; commit hashes are unsuitable for the
numeric package revision ([`making-packages.md`][making-packages]).

Application identity is operational state. Windows package family identity derives from
name and certificate subject; macOS identity combines reverse-DNS bundle ID and team ID.
Changing these can sever upgrades or permissions, so the generated site records prior
identity and the Windows escape hatch can perform a controlled reinstall
([`name-changes.md`][name-changes], [`escape-hatch.md`][escape-hatch]).

### Installation, upgrade, and uninstall

`[source-verified]` Lifecycle ownership is deliberately native:

- Windows' deployment engine installs the MSIX; the wrapper installer works around App
  Installer behavior, installs self-signed certificates when needed, and reopens an
  already-installed app. MSIX containerization supplies clean removal and OS-managed
  upgrade behavior.
- macOS remains an application-bundle replacement model. Sparkle stages and replaces the
  bundle on update; deleting the app is the ordinary uninstall path.
- Debian/Ubuntu installs through `dpkg`/APT. The package installs an APT source descriptor
  for future dependency resolution and updates. Maintainer scripts register desktop
  files/services, stop and restart services across upgrades, and clean up on uninstall.
- ZIP/tar outputs have no package database and no Conveyor-managed update or uninstall.

These are package/updater semantics, not release orchestration. Conveyor generates the
artifacts and metadata that each native authority consumes; it does not replace Windows
Deployment, Sparkle, or APT ([`package-formats.md`][formats],
[`understanding-updates.md`][updates]).

### Signing and platform trust

`[source-verified]` Conveyor documents one root entropy value from which it manages or
derives multiple trust paths: Windows code/package signatures, Apple code signing,
Sparkle EdDSA feed signatures, and Debian/APT OpenPGP signing
([`configs/index.md`][config-index], [`keys-and-certificates.md`][keys]).

Windows binaries and MSIX files can be Authenticode-signed and timestamped with local
keys, HSMs, remote signing services, or custom scripts. macOS nested code is signed,
submitted to Apple's notarization service, and stapled; the product documents doing this
without a macOS host. Debian packages/repository metadata are GPG-signed. Native platform
signatures, updater-feed signatures, and repository signatures are distinct even though
Conveyor derives their keys from common root material.

Self-signing is a development/low-cost path, not equivalent to public CA/Developer ID
trust. Microsoft Store publication uses Store identity/signing. Apple credentials and
notarization passwords remain secrets; CI examples inject them through environment-backed
configuration. The OSS repository does not expose the cryptographic implementation, so
algorithm use and key handling beyond documented contracts could not be audited.

### Publication and discovery

`[source-verified]` `site` is artifact construction; `copied-site` is publication.
Conveyor can copy a site to a filesystem/SSH-style destination, S3-compatible storage,
or GitHub Releases, and can submit later Microsoft Store releases after the required
manual first submission ([`uploading.md`][uploading], [`windows.md`][windows]). Stable,
immutable payloads are uploaded before volatile metadata so readers do not observe an
index pointing at missing assets ([`configuring-cdns.md`][cdns]).

The generated static site detects OS/architecture and exposes native packages plus
archive alternatives. Installed applications discover updates from the same base URL.
GitHub's `/releases/latest` behavior is explicitly unsuitable for beta/pre-release
streams unless separate locations or draft policy are used. Conveyor does not publish
to the Mac App Store, Linux distro repositories beyond its generated APT repository, or
community catalogs such as Homebrew and WinGet.

This publication support does not make Conveyor a full release control plane. It can
build/upload its own outputs, but source tagging, changelog/release-note policy, test
gates, SBOM/provenance fan-in, promotion, and announcement remain external CI concerns.

### Updates and release channels

`[source-verified]` Windows checks `.appinstaller` metadata and can update silently in
the background or synchronously at launch. Its block map provides chunk-level delta
transfer. macOS uses embedded Sparkle, signed appcasts, and binary delta patches from a
configurable number of earlier releases. Debian delegates refresh and upgrade to APT.
Archives do not update automatically ([`understanding-updates.md`][updates],
[`performance.md`][performance]).

The `metadata.properties` file also supports site migration and package-identity repair.
Conveyor can use separate site URLs/license keys for stable, beta, or canary channels,
but it does not document a hosted percentage/cohort rollout controller. A channel is
primarily a separately published repository/feed. Installed update engines poll public,
unauthenticated metadata, so publication ordering and signing are central to safety.

### Automation and CI

`[source-verified]` The checked-in guide provides a GitHub Action and generic CI
recipes. A typical job obtains target inputs, injects `SIGNING_KEY` and Apple
notarization credentials, preserves the Conveyor cache, and invokes:

```bash
conveyor -f ci.conveyor.conf make copied-site
```

The proprietary task engine runs independent work in parallel (`--parallelism` defaults
to four) and caches intermediate outputs. Previous packages/site metadata are inputs to
delta generation and identity consistency checks, so preserving cache and retaining the
published site materially improve subsequent releases ([`continuous-integration.md`][ci]).
The checked-in composite Action downloads a versioned Linux x64 Conveyor archive,
restores its cache, requires explicit EULA acceptance, and rejects non-Linux runners
([`actions/build/action.yml`][action]). It does not verify that downloaded archive against
a pinned content digest.

Native target hosts are **not required for packaging** according to the guide, which is
the principal difference from most OSS desktop packagers. Native compilation and
runtime validation still need suitable toolchains or test machines. This review was
performed on Linux and made no Windows/macOS artifact, signing, install, or update claim
`[host-verified]`.

### Supply-chain evidence and reproducibility

`[source-verified]` Positive controls include content-addressed intermediate caching,
immutable-versus-volatile upload ordering, signed native packages/update metadata,
identity consistency probes, timestamping, notarization, and stable/versioned input URL
expectations. The Action examples isolate signing material in CI secrets. The OSS
repository's own Gradle build and workflows are reviewable, but not the engine that
creates application artifacts.

Conveyor does **not** document byte-for-byte reproducible final packages, an application
SBOM, SLSA provenance, or an attestation manifest. Signing timestamps, notarization,
remote inputs, generated repositories, archive metadata, and proprietary tool versions
are obvious reproducibility boundaries. URL inputs are assumed immutable and cached;
`--rerun=all` is required when bytes change behind a URL ([`continuous-integration.md`][ci]).
Consumers therefore need external checksum/SBOM/provenance generation and should pin
Conveyor plus every input URL/version in their release pipeline.

### Extensibility and UX

`[source-verified]` HOCON composition, standard-library includes, machine inheritance,
command-output/hashbang includes, raw config fragments, arbitrary input remapping,
custom signing scripts, and more than 120 keys form the extension surface. CMake
scaffolding and Electron/JVM/Flutter presets reduce initial configuration. The OSS
Gradle plugin is extensible and test-covered, but there is no OSS backend API from which
a community can implement a new package format; those backends live in the proprietary
core.

The UX favors one declarative command and inspectable intermediate tasks. Generated
sites and native update systems reduce application code; control APIs are optional for
Electron/JVM/native applications. The trade-off is product coupling at build time,
limited format selection, a paid license for proprietary applications, and an evidence
gap: users can inspect generated artifacts and docs, but not the implementation that
constructs or signs them.

## Strengths

- Produces package, updater metadata, download UI, and selected publication from one DAG.
- Documented cross-packaging—including Apple signing/notarization from Linux—can collapse
  the packaging matrix after target binaries are available.
- Uses native lifecycle authorities instead of imposing one updater on every OS.
- Strong signing coverage across Windows, macOS/Sparkle, and Debian/APT.
- Content-addressed incremental cache and delta history make repeated releases efficient.
- Explicit stable/volatile publication ordering avoids partially visible releases.
- Framework presets remain compatible with arbitrary native payloads.

## Weaknesses

- The packaging/signing/updater core is proprietary and could not be source-audited.
- Proprietary projects require a paid per-project license; free OSS use carries branding
  requirements on the generated site.
- Output coverage is opinionated: no MSI, RPM, AppImage, Flatpak, Snap, DMG, PKG, or Mac
  App Store path.
- It is not a complete release control plane: compilation, tests, version planning,
  changelogs, SBOM/provenance, promotion, and announcements remain external.
- No documented byte-reproducibility, generated SBOM, or signed provenance.
- Generic channels are separate sites rather than a first-class staged-rollout service.
- Cross-host claims were documentation-verified only; no Windows/macOS artifact was
  host-verified in this review.

## Key design decisions and trade-offs

| Decision                                                 | Rationale                                                 | Trade-off                                                                  |
| -------------------------------------------------------- | --------------------------------------------------------- | -------------------------------------------------------------------------- |
| Consume prebuilt machine inputs                          | Remain language/framework neutral                         | Compilation and native runtime testing stay external                       |
| Use MSIX/App Installer, Sparkle, and APT                 | Preserve native updates, identity, and uninstall behavior | Lifecycle semantics and supported formats differ by OS                     |
| Implement cross-host signing/packaging                   | Permit a small Linux-centric release CI matrix            | Complex implementation is proprietary and difficult to independently audit |
| Make `site` the default aggregate                        | Produce packages and update discovery together            | A public base URL becomes mandatory application state                      |
| Separate `site` from `copied-site`                       | Keep construction distinct from publication               | Users must choose and secure a publication adapter                         |
| Cache a declarative task DAG by content                  | Reuse expensive packaging/signing/delta work              | Cache and prior-site retention become operational dependencies             |
| Upload immutable payloads before volatile indexes        | Prevent readers observing incomplete releases             | Publication adapters must preserve ordering and retry semantics            |
| Derive several trust keys from root entropy              | Simplify multi-platform key management                    | One root secret has a broad blast radius                                   |
| Offer free OSS use and paid proprietary use              | Sustain a commercial tool while serving OSS               | Capability is not an entirely OSS dependency                               |
| Expose configuration escape hatches, not backend plugins | Keep native complexity behind one product                 | Community cannot add package formats without vendor implementation         |

## Sources

- [Repository and exact reviewed tree (`v22.0`)][revision]
- [`README.md` — OSS/proprietary repository boundary and product positioning][readme]
- [`guidebook/docs/index.md` — product scope and host claims][guide-index]
- [`guidebook/docs/running.md` — tasks, DAG, output, and cache][running]
- [`guidebook/docs/configs/inputs.md` — input hierarchy and staging][inputs]
- [`guidebook/docs/package-formats.md` — artifacts and native lifecycle owners][formats]
- [`guidebook/docs/understanding-updates.md` — Windows, Sparkle, and APT updates][updates]
- [`guidebook/docs/configs/keys-and-certificates.md` — trust model][keys]
- [`guidebook/docs/continuous-integration.md` — CI, secrets, and cross-host release flow][ci]
- [`guidebook/docs/serving/uploading.md` — S3, GitHub, and Store publication][uploading]
- [`gradle-plugin/` implementation and tests — the reviewable OSS metadata bridge][gradle-tree]
- [`actions/build/action.yml` — Linux-only composite Action and binary download][action]

<!-- References -->

[repo]: https://github.com/hydraulic-software/conveyor
[docs]: https://conveyor.hydraulic.dev/
[revision]: https://github.com/hydraulic-software/conveyor/tree/9e90ce7c2a4356c99d68c63f41e4bc497da279c8
[readme]: https://github.com/hydraulic-software/conveyor/blob/9e90ce7c2a4356c99d68c63f41e4bc497da279c8/README.md
[guide-index]: https://github.com/hydraulic-software/conveyor/blob/9e90ce7c2a4356c99d68c63f41e4bc497da279c8/guidebook/docs/index.md
[running]: https://github.com/hydraulic-software/conveyor/blob/9e90ce7c2a4356c99d68c63f41e4bc497da279c8/guidebook/docs/running.md
[performance]: https://github.com/hydraulic-software/conveyor/blob/9e90ce7c2a4356c99d68c63f41e4bc497da279c8/guidebook/docs/performance.md
[inputs]: https://github.com/hydraulic-software/conveyor/blob/9e90ce7c2a4356c99d68c63f41e4bc497da279c8/guidebook/docs/configs/inputs.md
[config-index]: https://github.com/hydraulic-software/conveyor/blob/9e90ce7c2a4356c99d68c63f41e4bc497da279c8/guidebook/docs/configs/index.md
[formats]: https://github.com/hydraulic-software/conveyor/blob/9e90ce7c2a4356c99d68c63f41e4bc497da279c8/guidebook/docs/package-formats.md
[updates]: https://github.com/hydraulic-software/conveyor/blob/9e90ce7c2a4356c99d68c63f41e4bc497da279c8/guidebook/docs/understanding-updates.md
[keys]: https://github.com/hydraulic-software/conveyor/blob/9e90ce7c2a4356c99d68c63f41e4bc497da279c8/guidebook/docs/configs/keys-and-certificates.md
[windows]: https://github.com/hydraulic-software/conveyor/blob/9e90ce7c2a4356c99d68c63f41e4bc497da279c8/guidebook/docs/configs/windows.md
[ci]: https://github.com/hydraulic-software/conveyor/blob/9e90ce7c2a4356c99d68c63f41e4bc497da279c8/guidebook/docs/continuous-integration.md
[uploading]: https://github.com/hydraulic-software/conveyor/blob/9e90ce7c2a4356c99d68c63f41e4bc497da279c8/guidebook/docs/serving/uploading.md
[cdns]: https://github.com/hydraulic-software/conveyor/blob/9e90ce7c2a4356c99d68c63f41e4bc497da279c8/guidebook/docs/configuring-cdns.md
[making-packages]: https://github.com/hydraulic-software/conveyor/blob/9e90ce7c2a4356c99d68c63f41e4bc497da279c8/guidebook/docs/faq/making-packages.md
[name-changes]: https://github.com/hydraulic-software/conveyor/blob/9e90ce7c2a4356c99d68c63f41e4bc497da279c8/guidebook/docs/name-changes.md
[escape-hatch]: https://github.com/hydraulic-software/conveyor/blob/9e90ce7c2a4356c99d68c63f41e4bc497da279c8/guidebook/docs/configs/escape-hatch.md
[gradle-readme]: https://github.com/hydraulic-software/conveyor/blob/9e90ce7c2a4356c99d68c63f41e4bc497da279c8/gradle-plugin/README.md
[gradle-plugin]: https://github.com/hydraulic-software/conveyor/blob/9e90ce7c2a4356c99d68c63f41e4bc497da279c8/gradle-plugin/src/main/kotlin/hydraulic/conveyor/gradle/ConveyorGradlePlugin.kt
[gradle-task]: https://github.com/hydraulic-software/conveyor/blob/9e90ce7c2a4356c99d68c63f41e4bc497da279c8/gradle-plugin/src/main/kotlin/hydraulic/conveyor/gradle/ConveyorConfigTask.kt
[gradle-tree]: https://github.com/hydraulic-software/conveyor/tree/9e90ce7c2a4356c99d68c63f41e4bc497da279c8/gradle-plugin
[action]: https://github.com/hydraulic-software/conveyor/blob/9e90ce7c2a4356c99d68c63f41e4bc497da279c8/actions/build/action.yml
