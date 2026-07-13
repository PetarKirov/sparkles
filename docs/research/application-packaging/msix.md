# MSIX (Windows identity-based application package)

MSIX is Microsoft's signed, ZIP/OPC-derived application package whose manifest identity,
block map, and deployment registration bind installation, updates, integrity, and clean
removal.

| Field                   | Value                                                                                                                                                                |
| ----------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Format/tool languages   | XML manifests; ZIP/Open Packaging Conventions; PKCS #7 signature; Microsoft SDK in C++                                                                               |
| License                 | Microsoft MSIX SDK: MIT                                                                                                                                              |
| Repository              | [microsoft/msix-packaging][repo]                                                                                                                                     |
| Documentation           | [Microsoft MSIX documentation][docs]                                                                                                                                 |
| Reviewed revision       | [`efeb9dad695a200c2beaddcba54a52c8320bd135`][revision] (`MSIX-Core-1.2-release-27-gefeb9dad`)                                                                        |
| Category                | Signed native package/deployment format plus SDK; not a release orchestrator                                                                                         |
| Supported hosts/targets | SDK can pack/unpack on Windows, macOS, and Linux; authoritative deployment, app-model validation, Store submission, and normal SignTool workflows are Windows-native |
| OSS/paid boundary       | Format SDK is MIT; Microsoft Store accounts/policies and commercial certificates/signing services are separate                                                       |

**Last reviewed:** July 12, 2026

## Overview

### What it solves

MSIX gives Windows applications a stable package identity, declarative capabilities and
entry points, architecture/resource selection, tamper-evident payload, managed updates,
and package-owned removal. It applies modern deployment semantics to UWP applications
and suitably packaged desktop applications while retaining compatibility mechanisms for
traditional Win32 software.

The reviewed SDK describes its portability boundary precisely:

> “The MSIX SDK project includes cross platform API support for packing and unpacking
> of .msix/.appx packages” — [`README.md`][readme]

That statement does **not** mean cross-platform hosts reproduce Windows deployment or
Store policy. `makemsix` can construct/read the container; Windows deployment services
interpret identity, extensions, capabilities, virtualization, signatures, dependencies,
and update relationships.

### Design philosophy

MSIX replaces arbitrary system mutation with a declared package graph and a sealed
payload. Identity determines whether versions are related; the block map makes content
addressable in fixed-size pieces; the signature authenticates the package footprint;
and deployment owns registration and removal. Traditional applications that assume
unrestricted writes beside the executable, global registry mutation, drivers, or
arbitrary services may require modification, Packaging Support Framework fixes, or a
different installer format.

## How it works

A package contains payload plus standardized footprint files:

```text
AppxManifest.xml
AppxBlockMap.xml
AppxSignature.p7x
[Content_Types].xml
Assets/...
app.exe
```

`AppxManifest.xml` declares `Identity` (`Name`, `Publisher`, `Version`,
`ProcessorArchitecture`, and optional `ResourceId`), target device families,
properties, resources, dependencies, capabilities, and application extensions. The
reviewed source computes:

```text
package full name = name_version_architecture_resourceId_publisherId
package family name = name_publisherId
```

where `publisherId` is the Base32 encoding of SHA-256 over the UTF-16 publisher
string ([`AppxPackageInfo.hpp`][package-info]). The family therefore stays stable only
when `Name` and `Publisher` stay stable.

The package writer divides files into 65,536-byte uncompressed blocks and emits hashes
and compressed sizes in `AppxBlockMap.xml` ([`AppxBlockMapWriter.hpp`][block-map]). The
block map supports per-block verification and differential transfer. Signing then adds
`AppxSignature.p7x`; mutating payload, manifest, content types, or block map afterward
invalidates the package signature.

## Analysis spine

### Input and staging

Start from a deterministic package layout with executable/runtime closure, assets, and a
schema-valid manifest. Manifest declarations are not decoration: entry points,
capabilities, aliases, protocols, file types, services, dependencies, architecture,
minimum OS, and trust mode control deployment and runtime behavior. Test traditional
Win32 assumptions against MSIX filesystem/registry rules rather than merely repackaging
an installer output.

`MakeAppx.exe`, MSIX Packaging Tool, Visual Studio, and the OSS SDK can construct
packages; the reviewed `makemsix` wraps SDK pack/unpack APIs. Package directly from the
layout—do not put an MSI/setup EXE inside MSIX and expect its machine mutations to run.

### Outputs and targets

A `.msix` contains one package identity/architecture/resource variant. A
`.msixbundle` contains related architecture and resource packages plus
`AppxMetadata/AppxBundleManifest.xml`; deployment selects applicable payloads. Bundles
reduce catalog clutter and avoid installing irrelevant architecture/language assets.
For an ordinary contained bundle, signing the final bundle covers its contained
packages; a flat bundle references external package files, so every external package
and the flat bundle must be signed with the same certificate.

Optional/resource packages and framework dependencies separate content. An
`.msixupload` is a Store-submission container, not the end-user installed package. MSIX
Core extends selected install support to older Windows, but it is a separate client and
does not make all modern Windows app-model features available there.

A **sparse package** supplies package identity/manifest registration while application
files live in an external location. It helps an existing desktop installation gain
identity-dependent APIs/extensions without moving the complete payload into the normal
package store. The external files retain their own installer/updater/uninstall owner;
sparse registration is not a way to claim MSIX owns those bytes.

### Metadata and dependencies

`Identity` is the upgrade anchor:

- `Name` plus derived publisher ID forms the package family.
- `Publisher` must match the signing certificate subject for ordinary sideloaded
  packages; Store-assigned identity/certification follows Store policy.
- `Version` is four dot-separated unsigned 16-bit integers, not arbitrary SemVer.
- `ProcessorArchitecture` and `ResourceId` distinguish package variants while preserving
  family relationships.

Changing `Name` or `Publisher` creates a different family rather than an upgrade.
Changing only display name does not. Reserve identity before the first public release
and define a deterministic SemVer-to-four-part version mapping.

`Dependencies` declares framework/package dependencies with names, publishers, and
minimum versions, and `TargetDeviceFamily` sets OS family/minimum version. This is a
package graph, not a general-purpose online dependency solver: dependencies must be in
the Store, App Installer set, provisioning system, or installation command context.

### Installation, upgrade, and uninstall

Windows deployment validates schema, applicability, dependency graph, package identity,
block hashes, signature, and trust before staging/registering the package for a user.
Files live under deployment-owned package locations and are not mutable program files.
Desktop integration comes from manifest declarations rather than an installer writing
arbitrary shortcuts/registry keys.

A higher version in the same package family updates the installed package. Windows can
stage changed blocks rather than redownload unchanged file blocks, and activation can
move to the new registered version. Downgrade is normally rejected; explicit deployment
or App Installer policy such as `ForceUpdateFromAnyVersion` is required when a lower
version must replace a higher one.

Uninstall unregisters the package, removes its deployment-owned files under the package
location, and removes captured redirected AppData/registry writes. It does not remove
data deliberately written to unowned external locations, nor bytes owned by an MSI/EXE
behind a sparse package. App Installer's 2021 schema can provide repair sources and
package-integrity remediation, but this is package replacement/re-registration—not MSI
component key-path repair. Deployment failure is transactional package-state recovery,
not author-scripted undo of arbitrary privileged custom actions; there is no generic
user-facing “roll back to the previous release” history. A lower version requires an
explicit downgrade/`ForceUpdateFromAnyVersion` path.

### Signing and platform trust

Normal distribution requires a signed package whose certificate is trusted on the
target and whose subject exactly matches manifest `Publisher`. Store distribution is
signed/served under Store identity policy; enterprise/private sideloading must deploy a
trusted certificate or use an approved trust path. Developer/explicit
`AllowUnsigned` flows are exceptions and must not be presented as release trust.

`AppxSignature.p7x` is a PKCS #7 signature over package footprint digests, including the
block map. The reviewed validator fails when that file is missing and calls
`WinVerifyTrust` to validate both certificate signature and timestamp
([`SignatureValidator.cpp`][signature-validator]). Use `signtool sign /fd SHA256` and an
RFC 3161 timestamp (`/tr` with `/td SHA256`) under current Microsoft guidance, then use
`signtool verify /pa` and deployment tests. Sign nested PE binaries too when their own
publisher/reputation boundary matters; the package signature and an executable's
Authenticode signature are distinct envelopes.

Sign only after packaging has finalized the block map. Repacking a signed MSIX, editing
its manifest, or changing compression invalidates `AppxSignature.p7x`.

### Publication and discovery

MSIX packages/bundles can be published through Microsoft Store, enterprise management,
provisioning, direct HTTPS, or an App Installer document. The Store provides catalog,
policy, acquisition, licensing where applicable, and updates. Direct hosting provides
only bytes unless paired with trusted certificate distribution and an update mechanism.

An `.appinstaller` file is a separate XML manifest with its own `Uri` and four-part
`Version`. It points to a `MainPackage` or `MainBundle`, optional/related packages and
dependencies, and update/repair settings. It is **not** the application package and does
not embed payload. Protect its stable HTTPS origin and keep every declared identity,
version, URI, and signature relationship consistent.

### Updates and release channels

App Installer can check on launch (`OnLaunch`/`HoursBetweenUpdateChecks`), use an
automatic background task, prompt users, block activation until an update, and—when
explicitly configured—force update from any version. Availability and exact schema
features depend on Windows version, so declare the appropriate namespace and test the
minimum target OS.

Package version controls applicability; the App Installer URI controls discovery.
Publish new immutable package URLs, then update the App Installer document. Separate
stable/beta channels should use separate App Installer URIs and, when coexistence is
required, separate package families. One family cannot simultaneously represent two
independently installed channels.

Store updates and App Installer updates are different control planes. Do not also run an
in-app binary replacer against deployment-owned package files.

### Automation and CI

CI should validate manifest schemas, pack, inspect/unpack, verify block map and
signatures, and retain package/bundle inventory. Windows jobs should run Windows App
Certification Kit where relevant and exercise clean install, dependency acquisition,
launch/aliases/protocols, update, downgrade rejection/forced downgrade policy, offline
failure, repair/reset, and uninstall for every architecture and supported OS.

The OSS SDK demonstrates cross-platform pack/unpack and contains readers/writers for
manifest, block map, bundle, and signature structures. Final SignTool/Store submission
and authoritative deployment remain Windows-native boundaries. This page is
`[source-verified]` and `[spec-verified]`; no package was
`[host-verified: windows]` here.

### Supply-chain evidence and reproducibility

The block map gives each package a built-in chunk-integrity inventory and the package
signature binds that footprint to a publisher. Preserve manifest and bundle manifest,
block-map digest, inner and outer package hashes, signer chain/thumbprint, timestamp,
SDK/tool versions, WACK results, SBOM, and provenance. An App Installer file and Store
submission metadata need separate provenance because they control discovery.

Deterministic staging, ZIP ordering/compression, generated XML, and tool versions can
make unsigned packages comparable. Signatures and trusted timestamps make final bytes
time-dependent. Differential delivery is a bandwidth feature, not proof that two builds
are reproducible.

### Extensibility and UX

Manifest extensions expose aliases, protocols, file associations, startup tasks,
services, COM integration, and other Windows capabilities under versioned schemas. The
Packaging Support Framework can apply runtime fixes to traditional applications.
Optional packages, modification packages, sparse packages, and bundles cover special
composition cases, but each adds identity/deployment relationships to test.

The default UX is intentionally low-choice and deployment-owned. Apps needing arbitrary
install directories, interactive prerequisite selection, drivers, unrestricted machine
scripts, or heavily customized setup may fit MSI or a setup EXE better. Do not recreate
an imperative installer through fragile launch-time workarounds.

## Strengths

- Cryptographic package identity and sealed payload.
- Block-map verification and bandwidth-efficient differential updates.
- Clean deployment-owned install/update/uninstall without installer custom actions.
- Bundles select architecture and resources from one distribution object.
- Store, enterprise, and App Installer channels share the same package identity.
- Declarative integration is auditable in `AppxManifest.xml`.

## Weaknesses

- Traditional desktop assumptions can conflict with package immutability/virtualization.
- Publisher/name/version identity mistakes create permanent upgrade/channel problems.
- Signature/certificate trust is mandatory for ordinary private distribution.
- Four-part numeric versions need an explicit mapping from SemVer.
- App Installer schema/behavior varies with Windows versions and adds another mutable manifest.
- Sparse packages split lifecycle ownership between registration and external files.
- Windows-native validation is still required despite cross-platform container tooling.

## Key design decisions and trade-offs

| Decision                             | Rationale                                     | Trade-off                                                    |
| ------------------------------------ | --------------------------------------------- | ------------------------------------------------------------ |
| Stable `Name` + `Publisher` family   | Make updates and runtime identity unambiguous | Publisher migration creates a new identity problem           |
| Immutable package payload            | Enable clean deployment and integrity         | Apps cannot update files in place                            |
| 64 KiB block map                     | Verify and transfer only changed chunks       | Adds generated footprint metadata and strict sealing         |
| Bundle architecture/resources        | Deliver one applicable set per device         | Bundle/inner identity and signing become more complex        |
| App Installer as separate feed       | Add direct-hosted update discovery            | Stable feed URI becomes security/availability infrastructure |
| Sparse package only for bridge cases | Give external Win32 apps identity             | External installer still owns files and cleanup              |

## Sources

- [MSIX SDK repository at exact reviewed revision][revision], locally read from
  `$REPOS/msix-packaging` (`README.md`, package/bundle readers/writers, validation,
  schemas, MSIX Core, and tests)
- [MSIX package format overview][package-format]
- [MSIX package manifest schema][manifest-schema]
- [Package identity overview][identity]
- [App package block map schema][block-map-schema]
- [Sign an app package using SignTool][sign-package]
- [MSIX bundles][bundles]
- [Sparse package overview][sparse]
- [App Installer file overview and update settings][appinstaller]
- [Microsoft Store package requirements][store-requirements]
- Related: [packaging concepts][concepts] · [Windows portable][portable] · [WiX/MSI][wix]

<!-- References -->

[repo]: https://github.com/microsoft/msix-packaging
[revision]: https://github.com/microsoft/msix-packaging/tree/efeb9dad695a200c2beaddcba54a52c8320bd135
[readme]: https://github.com/microsoft/msix-packaging/blob/efeb9dad695a200c2beaddcba54a52c8320bd135/README.md
[package-info]: https://github.com/microsoft/msix-packaging/blob/efeb9dad695a200c2beaddcba54a52c8320bd135/src/inc/internal/AppxPackageInfo.hpp#L91-L135
[block-map]: https://github.com/microsoft/msix-packaging/blob/efeb9dad695a200c2beaddcba54a52c8320bd135/src/inc/internal/AppxBlockMapWriter.hpp
[signature-validator]: https://github.com/microsoft/msix-packaging/blob/efeb9dad695a200c2beaddcba54a52c8320bd135/src/msix/PAL/Signature/Win32/SignatureValidator.cpp#L500-L644
[docs]: https://learn.microsoft.com/windows/msix/
[package-format]: https://learn.microsoft.com/en-us/windows/msix/overview
[manifest-schema]: https://learn.microsoft.com/uwp/schemas/appxpackage/uapmanifestschema/schema-root
[identity]: https://learn.microsoft.com/windows/apps/desktop/modernize/package-identity-overview
[block-map-schema]: https://learn.microsoft.com/en-us/uwp/schemas/blockmapschema/root-elements
[sign-package]: https://learn.microsoft.com/windows/msix/package/sign-app-package-using-signtool
[bundles]: https://learn.microsoft.com/windows/msix/package/bundling-overview
[sparse]: https://learn.microsoft.com/en-us/windows/apps/desktop/modernize/package-identity-overview
[appinstaller]: https://learn.microsoft.com/windows/msix/app-installer/app-installer-file-overview
[store-requirements]: https://learn.microsoft.com/windows/apps/publish/publish-your-app/msix/app-package-requirements
[concepts]: ./concepts.md
[portable]: ./windows-portable.md
[wix]: ./wix-msi.md
