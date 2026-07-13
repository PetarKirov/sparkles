# Swift Bundler (Swift / application packager)

Swift Bundler builds SwiftPM applications and materializes native app layouts, portable
Linux/Windows directories, AppImages, RPMs, MSIs, and Android APKs with host-specific
backend tooling.

| Field                   | Value                                                                                     |
| ----------------------- | ----------------------------------------------------------------------------------------- |
| Language                | Swift 6                                                                                   |
| License                 | Apache-2.0                                                                                |
| Repository              | [stackotter/swift-bundler][repo]                                                          |
| Documentation           | [README][readme] · [configuration schema][schema]                                         |
| Reviewed source         | [`4ad3f14f0b4c292f5bb57105b834be7f321c4f05`][reviewed]                                    |
| Category                | **Application builder/packager**; not a release control plane or updater                  |
| Supported hosts/targets | macOS Apple bundles and Android APK; Linux generic/AppImage/RPM; Windows generic/MSI      |
| OSS/paid boundary       | Fully open source; no paid build, signing, or publication service in the reviewed project |

**Last reviewed:** July 12, 2026

> [!IMPORTANT]
> Swift Bundler owns more than a low-level format encoder: it reads a Swift package,
> builds products, copies resources/runtime libraries, writes platform metadata, and
> invokes package backends. It still stops at local artifacts. It does not schedule a
> release matrix, host/publish artifacts, submit stores/catalogs, notarize releases, or
> provide an installed update client.

---

## Overview

### What it solves

Swift Bundler presents SwiftPM projects as applications rather than bare executables.
Its README positions it as:

> “An Xcodeproj-less tool for creating cross-platform Swift apps.”
>
> — [`README.md`][readme]

`swift bundler bundle` resolves an app from `Bundler.toml`, builds the SwiftPM product
(or uses build artifacts), and dispatches a bundler selected for the target. The bundler
creates the expected directory/bundle, copies resources and dynamic dependencies, writes
metadata, and may invoke a format tool ([`BundleCommand.swift`][bundle-command],
[`Bundler.swift`][bundler-protocol]). The same project also supports development run,
hot reload, device/simulator paths, templates, and Xcode support, but those are adjacent
developer UX—not release distribution.

### Design philosophy

The code separates a **generic build context** from backend-specific `Bundler`
implementations. The protocol asks each backend for host compatibility, extra SwiftPM
arguments, intended output, and `bundle()` behavior. A generic Linux or Windows bundle
is reusable staging for AppImage/RPM or MSI respectively
([`GenericLinuxBundler.swift`][generic-linux], [`MSIBundler.swift`][msi]).

This is explicit composition rather than a claim that every platform is portable.
`BundlerChoice.supportedHostPlatforms` declares Apple bundling only on macOS, Linux
backends only on Linux, Windows backends only on Windows, and Android APK on all three
hosts. The command-level validator is stricter: on Linux and Windows it rejects every
non-native target, so the reviewed CLI's effective Android cross-build path is macOS-only
([`BundlerChoice.swift`][bundler-choice], [`BundleCommand.swift`][bundle-command]).

## How it works

A project's `Bundler.toml` supplies application identity and packaging metadata while
`Package.swift` remains the compilation/dependency graph:

```toml
format_version = 2

[apps.Acme]
identifier = "com.example.acme"
product = "Acme"
version = "1.2.3"
category = "public.app-category.utilities"
```

The high-level graph is:

```text
Package.swift + Bundler.toml + resources
  -> SwiftPM/xcodebuild target products
  -> target-specific app staging
  -> optional AppImage / RPM / MSI / APK backend
  -> local output directory
```

`PackageConfiguration` loads `Bundler.toml`, supports multiple apps and configuration
overlays, checks format/config compatibility, and can migrate earlier JSON/TOML forms
([`PackageConfiguration.swift`][package-config]). `BundleCommand` resolves platform,
architecture, device, builder, signing context, and selected bundler before building and
dispatching.

## Analysis dimensions

### Input and staging

Inputs include the Swift package graph, selected executable product, `Bundler.toml`, icons,
`Info.plist` additions, resources, target/product configuration, built executable
dependencies, and signing parameters. Swift Bundler can build the product itself and has
special paths for `xcodebuild`, universal Apple binaries, cross-platform Swift SDKs, and
Android's Swift SDK/Gradle bridge.

Staging is backend-specific but layered:

- Darwin creates the platform bundle skeleton, copies executable/resources/frameworks and
  dynamic libraries, writes `Info.plist`/`PkgInfo`, adjusts load paths, then signs when
  configured ([`DarwinBundler.swift`][darwin]).
- generic Linux writes an FHS-like tree with executable, libraries, resources, desktop
  file, optional D-Bus service, and icons; it uses `ldd` plus an allowlist and `patchelf`
  rather than bundling every system library ([`GenericLinuxBundler.swift`][generic-linux]).
- generic Windows stages executable/dependencies/resources and embeds application metadata;
  MSI consumes that tree.

This is not a hermetic freeze. Host library inspection and external tools affect results,
and Linux deliberately excludes problematic libraries such as libc/GTK from automatic
vendoring.

### Outputs and target matrix

The checked-in `BundlerChoice` is the authoritative matrix:

| Bundler choice   | Output                                                                | Required host                  | Backend                                               |
| ---------------- | --------------------------------------------------------------------- | ------------------------------ | ----------------------------------------------------- |
| `darwinApp`      | macOS, Mac Catalyst, iOS/tvOS/visionOS device or simulator app bundle | macOS                          | Apple SDK/Xcode and `codesign` paths                  |
| `linuxGeneric`   | runnable `.generic` directory                                         | Linux                          | `ldd`, `patchelf`, filesystem staging                 |
| `linuxAppImage`  | `.AppImage`                                                           | Linux                          | generic Linux/AppDir plus `appimagetool`              |
| `linuxRPM`       | `.rpm`                                                                | Linux                          | generic Linux tree plus generated spec and `rpmbuild` |
| `windowsGeneric` | runnable generic Windows directory                                    | Windows                        | Windows resources/runtime handling                    |
| `windowsMSI`     | `.msi`                                                                | Windows                        | generic Windows tree plus WiX v4                      |
| `androidAPK`     | debug APK                                                             | macOS through the reviewed CLI | Swift Android SDK/NDK plus generated Gradle project   |

Swift SDK target support can cross-compile some binaries, but the chosen bundler and
command validation still constrain the host. In particular, a Linux runner cannot
produce/verify MSI or Apple bundle signing. Although `BundlerChoice` declares Android on
all three hosts, `BundleCommand.validateArguments` rejects the non-native Android target
on Linux and Windows at this revision; do not infer a working three-host CLI path from the
lower-level declaration alone.

### Metadata and dependencies

`AppConfiguration` covers identifier, product, version, category, icon, URL schemes,
files/documents, description, license, plist entries, DBus activation, RPM requirements,
MSI configuration, Android settings, and Windows settings
([`AppConfiguration.swift`][app-config]). Platform writers translate these into
`Info.plist`, desktop/D-Bus records, RPM spec fields, WiX XML, Windows resources, or an
Android manifest.

SwiftPM resolves source dependencies; packaging then vendors selected build products and
runtime libraries. RPM `Requires` remain native package declarations. The Linux allowlist
is a compatibility policy, not a complete dependency solver. MSI contains its staged
files and does not declare package-manager dependencies.

### Installation, upgrade, and uninstall

Generic directories and AppImages are portable payloads with no installation database.
Apple app bundles rely on device/Finder/store or another container. RPM delegates file
ownership, scripts, upgrades, and removal to RPM tooling. MSI generates WiX components,
a stable `UpgradeCode` derived from the bundle identifier unless overridden, major-upgrade
rules, shortcuts, uninstall shortcut, and removal metadata
([`MSIBundler.swift`][msi]). Android install/uninstall belongs to the platform package
manager.

Swift Bundler itself does not expose deployed-machine state, repair, rollback, or one
cross-format uninstall operation. Stable identifiers and versions are therefore critical
inputs to downstream lifecycle behavior.

### Signing and platform trust

Darwin bundling can select identities/provisioning profiles, invoke `/usr/bin/codesign`,
apply entitlements, and ad-hoc sign where appropriate. It signs during bundle construction,
not as an independent release trust service ([`DarwinCodeSigner.swift`][darwin-signer]).
The reviewed source contains no notarization submission or stapling workflow.

On Windows, Swift Bundler enumerates certificates from the current user's certificate
store and invokes `SignTool` with SHA-256 and RFC 3161 timestamp services; MSI signing
occurs after WiX builds the installer ([`WindowsCodeSigner.swift`][windows-signer],
[`MSIBundler.swift`][msi]). This is valuable native signing, but secret provisioning,
certificate lifecycle, isolated runners, and final release attestations remain external.
The Linux RPM backend does not sign packages or repository metadata; AppImage signing is
not implemented in this layer.

### Publication and discovery

Not applicable. Outputs remain in the configured local output directory. The project does
not create forge releases, upload assets, run `createrepo`, submit Homebrew/WinGet records,
publish AppImage update information, or submit Apple/Microsoft/Android stores. Building an
APK or MSI is not publication.

### Updates and release channels

Swift Bundler contains template-update and development hot-reload features, but those do
not update shipped applications. There is no application feed, delta protocol, channel,
rollout, promotion, or rollback service. Native package managers/stores or a separately
embedded updater must own upgrades after publication.

### Automation and CI

The CLI is scriptable, and checked-in GitHub workflows build Swift Bundler itself on
macOS, Linux, and Windows ([`.github/workflows/`][workflows]). A consumer release should
mirror the effective command validation with native jobs, then fan in local outputs for
checksums/signing completion/publication. Apple and Windows signing credentials should be scoped to their
native jobs.

Backend subprocesses (`xcodebuild`, `codesign`, `ldd`, `patchelf`, `appimagetool`,
`rpmbuild`, WiX, `SignTool`, Gradle/Android tools) are part of the execution contract.
Swift Bundler does not provision a hosted fleet, retry releases, collect outputs, or make
publication idempotent.

### Supply-chain evidence and reproducibility

No SBOM, provenance attestation, aggregate checksum manifest, or reproducibility report is
emitted. SwiftPM lockfiles can pin source dependencies, but packaged output also depends on
the Swift toolchain/SDK, architecture, host libraries discovered by `ldd`, generated UUIDs
and temp paths, external backend versions, timestamps, and signatures.

The MSI upgrade GUID is deterministically seeded from application identity when not
supplied, which stabilizes lifecycle identity; that is not whole-artifact reproducibility.
A release control plane must pin tools, preserve logs, hash final signed bytes, and attach
SBOM/provenance separately.

### Extensibility and UX

`Bundler` is a clear source-level extension protocol, and generic staging layers reduce
backend duplication. `Bundler.toml` supports overlays, multiple apps, versioned schema,
and migration. MSI configuration can add WiX extensions and extra WXS children, while
platform plist/metadata fields offer native escape hatches.

The same CLI can create templates, build, bundle, run, hot reload, list signing identities,
and generate Xcode support. That is strong application-developer UX, but the breadth also
means packaging may execute compilation and platform tooling rather than consume a fixed,
pre-audited install tree.

## Strengths

- Builds and stages SwiftPM apps rather than packaging only a bare executable.
- Uses reusable generic Linux/Windows staging beneath native package backends.
- States and enforces native-host restrictions in code.
- Handles runtime libraries/resources, platform metadata, and Apple/Windows code signing.
- Offers strong Swift-native configuration, migration, templates, run, and device UX.

## Weaknesses

- Native output matrix requires macOS, Linux, and Windows jobs plus several external tools.
- Linux library vendoring is intentionally incomplete and host-sensitive.
- No DEB, DMG/PKG container, Windows EXE/MSIX, repository, catalog, or publication backend.
- No notarization/stapling, Linux package signing, updater, channel management, SBOM, or
  provenance.
- Coupling build and packaging can make byte-for-byte reproducibility and artifact reuse
  harder than packaging a fixed staged tree.

## Key design decisions and trade-offs

| Decision                                         | Rationale                                              | Trade-off                                                 |
| ------------------------------------------------ | ------------------------------------------------------ | --------------------------------------------------------- |
| Treat SwiftPM product plus app metadata as input | Give Swift apps first-class bundles                    | Packaging is coupled to the Swift build graph             |
| Layer packages over generic staging              | Reuse resource/runtime layout logic                    | Generic-stage assumptions leak into native backends       |
| Enforce backend host lists                       | Use correct platform SDKs/tools                        | A multi-OS CI matrix is mandatory                         |
| Vendor selected runtime libraries                | Improve portability without bundling libc/GUI stacks   | Dependency closure is incomplete and host-sensitive       |
| Integrate native signing                         | Produce runnable/trusted platform bytes in one command | Secret handling and notarization remain external          |
| Stop at local artifacts                          | Keep focus on application development/packaging        | Another system must own release evidence and distribution |

## Sources

- Swift Bundler local clone at
  `/home/petar/code/repos/pkg-research-native/swift-bundler`, reviewed at
  `4ad3f14f0b4c292f5bb57105b834be7f321c4f05`.
- [`BundlerChoice.swift`][bundler-choice] for the output/host matrix and
  [`Bundler.swift`][bundler-protocol] for the backend contract.
- Darwin, generic Linux, AppImage, RPM, generic Windows, MSI, and APK implementations under
  [`Sources/SwiftBundler/Bundler/`][bundler-tree].
- Configuration model under [`Sources/SwiftBundler/Configuration/`][config-tree].
- Evidence level: `[source-verified]`; no Windows or macOS output was host-verified.

<!-- References -->

[repo]: https://github.com/stackotter/swift-bundler
[reviewed]: https://github.com/stackotter/swift-bundler/tree/4ad3f14f0b4c292f5bb57105b834be7f321c4f05
[readme]: https://github.com/stackotter/swift-bundler/blob/4ad3f14f0b4c292f5bb57105b834be7f321c4f05/README.md
[schema]: https://github.com/stackotter/swift-bundler/blob/4ad3f14f0b4c292f5bb57105b834be7f321c4f05/Bundler.schema.json
[bundle-command]: https://github.com/stackotter/swift-bundler/blob/4ad3f14f0b4c292f5bb57105b834be7f321c4f05/Sources/SwiftBundler/Commands/BundleCommand.swift
[bundler-choice]: https://github.com/stackotter/swift-bundler/blob/4ad3f14f0b4c292f5bb57105b834be7f321c4f05/Sources/SwiftBundler/Commands/BundlerChoice.swift
[bundler-protocol]: https://github.com/stackotter/swift-bundler/blob/4ad3f14f0b4c292f5bb57105b834be7f321c4f05/Sources/SwiftBundler/Bundler/Bundler.swift
[bundler-tree]: https://github.com/stackotter/swift-bundler/tree/4ad3f14f0b4c292f5bb57105b834be7f321c4f05/Sources/SwiftBundler/Bundler
[generic-linux]: https://github.com/stackotter/swift-bundler/blob/4ad3f14f0b4c292f5bb57105b834be7f321c4f05/Sources/SwiftBundler/Bundler/GenericLinuxBundler.swift
[darwin]: https://github.com/stackotter/swift-bundler/blob/4ad3f14f0b4c292f5bb57105b834be7f321c4f05/Sources/SwiftBundler/Bundler/DarwinBundler.swift
[darwin-signer]: https://github.com/stackotter/swift-bundler/blob/4ad3f14f0b4c292f5bb57105b834be7f321c4f05/Sources/SwiftBundler/Bundler/DarwinCodeSigner/DarwinCodeSigner.swift
[msi]: https://github.com/stackotter/swift-bundler/blob/4ad3f14f0b4c292f5bb57105b834be7f321c4f05/Sources/SwiftBundler/Bundler/MSIBundler.swift
[windows-signer]: https://github.com/stackotter/swift-bundler/blob/4ad3f14f0b4c292f5bb57105b834be7f321c4f05/Sources/SwiftBundler/Bundler/WindowsCodeSigner.swift
[package-config]: https://github.com/stackotter/swift-bundler/blob/4ad3f14f0b4c292f5bb57105b834be7f321c4f05/Sources/SwiftBundler/Configuration/PackageConfiguration.swift
[app-config]: https://github.com/stackotter/swift-bundler/blob/4ad3f14f0b4c292f5bb57105b834be7f321c4f05/Sources/SwiftBundler/Configuration/AppConfiguration.swift
[config-tree]: https://github.com/stackotter/swift-bundler/tree/4ad3f14f0b4c292f5bb57105b834be7f321c4f05/Sources/SwiftBundler/Configuration
[workflows]: https://github.com/stackotter/swift-bundler/tree/4ad3f14f0b4c292f5bb57105b834be7f321c4f05/.github/workflows
