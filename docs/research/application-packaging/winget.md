# WinGet (Windows package catalog and installer dispatcher)

WinGet is a Windows package-manager client plus source protocols: its community catalog
publishes versioned manifests that point to publisher-hosted installers, while the client
selects, verifies, and invokes the applicable installer or manages a portable payload.

| Field                  | Value                                                                                                                                               |
| ---------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| Languages              | C++ client, C#/PowerShell tooling, YAML manifests, JSON schemas                                                                                     |
| License                | MIT (`winget-cli`) and MIT (`winget-pkgs`)                                                                                                          |
| Client repository      | [microsoft/winget-cli][cli-repo]                                                                                                                    |
| Community catalog      | [microsoft/winget-pkgs][pkgs-repo]                                                                                                                  |
| Documentation          | [WinGet command documentation][source-doc] and checked-in manifest docs                                                                             |
| Reviewed revisions     | CLI [`22d5c7d891a30f9d1b52214ba4a6bdbb14183fb1`][cli-revision] · catalog [`84718c8a47370e50d49af08c24776ee8466a0d8d`][pkgs-revision]                |
| Category               | Package catalog/client and installer dispatcher; not a general artifact host                                                                        |
| Supported host/targets | Windows host; Windows installers and portable executables across declared architectures                                                             |
| OSS/paid boundary      | Client and manifest repository are OSS; default-source validation/publication uses operated Microsoft services not fully implemented in either tree |

**Last reviewed:** July 12, 2026

## Overview

### What it solves

WinGet gives users one search/install/upgrade/uninstall surface over heterogeneous
Windows distribution technologies—MSI/WiX, MSIX/AppX, installer EXEs, Store products,
archives, fonts, and portable executables. A manifest normalizes identity, version,
architecture, scope, locale, installer type, unattended switches, dependencies, and the
SHA-256 of each payload. The client chooses an applicable installer and delegates to the
underlying technology, except for portable packages that it places and registers itself.

The pinned catalog `README.md` states the control-plane boundary precisely:

> “This repository contains the manifest files for the **Windows Package Manager**
> default source.” — [`winget-pkgs/README.md`][pkgs-readme]

It does **not** contain the application payloads. `InstallerUrl` points to the publisher's
release location; catalog policy prefers official, stable, version-specific URLs so a
mutable “latest” object cannot silently turn a reviewed hash into a failed or different
install.

### Design philosophy

WinGet separates four responsibilities:

1. Publishers build and host installers or portable archives.
2. Contributors register exact versions in a schema-controlled manifest repository.
3. Microsoft moderation and automation validate manifests, URLs, payload hashes,
   malware reputation, install behavior, and package correlation before publication.
4. The client consumes a source index or REST API, downloads the selected payload,
   verifies it, and invokes technology-specific install/upgrade/uninstall behavior.

This model avoids repackaging signed vendor installers and gives one catalog vocabulary
across native technologies. Its cost is indirection: catalog availability does not imply
payload availability, and WinGet can only uninstall or upgrade as reliably as the
upstream installer identity and switches permit.

## How it works

A multi-file manifest normally separates package version, default locale, and installer
entries. The installer file binds a URL and checksum to architecture and behavior:

```yaml
PackageIdentifier: Example.Command
PackageVersion: 1.2.3
InstallerType: inno
Installers:
  - Architecture: x64
    InstallerUrl: https://example.invalid/example-1.2.3-x64.exe
    InstallerSha256: 0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF
    InstallerSwitches:
      Silent: /VERYSILENT /NORESTART
      SilentWithProgress: /SILENT /NORESTART
ManifestType: installer
ManifestVersion: 1.12.0
```

The pinned 1.12 schema and documentation require `InstallerSha256` and model
`InstallerType`, nested archive files, `PortableCommandAlias`, `Scope`, switch sets,
`UpgradeBehavior`, package/Windows-feature dependencies, expected return codes,
`AppsAndFeaturesEntries`, repair behavior, elevation, and authentication. Known
installer types supply standard silent arguments; generic EXEs need explicit switches.
The manifest can distinguish `Custom`, `Silent`, `SilentWithProgress`, `Interactive`,
`InstallLocation`, `Log`, `Upgrade`, and `Repair` behavior.

Installation flows through source lookup, manifest selection, applicability checks,
download, hash verification, installer execution, and post-install correlation. MSI,
MSIX, Inno, Nullsoft, Burn, and other handlers retain their native semantics. For
`portable`, [`PortableFlow.cpp`][portable-flow] copies one executable or an extracted
suite to a managed root, creates command-alias symlinks in WinGet's links directory,
adds an Apps & Features record, and tracks files for upgrade/uninstall.

## Analysis spine

### Input and staging

The public catalog input is YAML plus publisher-hosted payload URLs. Contributors can
use `wingetcreate new <Installer URL(s)>` and submit a pull request. The checked-in
[authoring guide][authoring] requires architecture to describe installed binaries, a
stable version-specific URL, and metadata that correlates the installed product with the
manifest. The client caches
a downloaded installer, verifies its SHA-256, and may extract one archive layer before
dispatching a nested installer or portable files.

WinGet does not compile, stage, sign, or host the vendor application. Local manifests
and third-party/private sources use the same install machinery but do not inherit the
community repository's validation. No Windows behavior in this survey was host-tested.

### Outputs and targets

For MSI/MSIX/EXE inputs, the output is whatever the upstream installer registers and
places; WinGet records/correlates package state but is not the transaction engine. It
supports architecture-, locale-, market-, scope-, and OS-version-specific installer
selection. ZIP support can dispatch a nested installer or a suite of portable binaries.

Portable output is different: WinGet owns the copied file tree, symlinks/aliases, PATH
integration, tracking metadata, and Apps & Features registration. The schema's
`ArchiveBinariesDependOnPath` can add the extracted location itself to PATH where tools
need sibling binaries. WinGet does not emit a redistributable installer or archive as
an output.

### Metadata and dependencies

Package identity and version live in version manifests; locale files carry publisher,
description, license, tags, URLs, agreements, and release notes; installer files carry
payload mechanics. `AppsAndFeaturesEntries` bridge catalog identity to ARP metadata such
as `DisplayName`, `DisplayVersion`, product/upgrade codes, and effective installer type.
This is essential when a bootstrap EXE invokes an embedded MSI or reports a version that
sorts differently from `PackageVersion`.

Package dependencies must come from the same source. Windows features can also be
declared; external dependencies and Windows libraries are present in the schema model
but documented as unsupported. The catalog therefore does not encode every runtime
precondition.

### Installation, upgrade, and uninstall

WinGet passes normalized or manifest-supplied switches to the installer and interprets
return codes. The underlying technology owns transaction, repair, reboot, and rollback.
Upgrade compares the installed/correlated version with source versions, respects pins
and applicability, then invokes the selected newer installer according to
`UpgradeBehavior`; a manifest may require uninstalling the previous technology first.
Uninstall generally uses registered ARP/MSIX/Store data rather than downloading a
catalog uninstaller.

Portable install/upgrade/uninstall is client-owned. It copies files, creates aliases and
an ARP entry, replaces tracked files in place during upgrade, and removes managed files
on uninstall. Generated application data is preserved unless purge behavior is selected;
this is persistence-by-nonownership, not a schema-declared persistent-data map like
Scoop's `persist`.

### Signing and platform trust

Every community installer entry binds the URL to required SHA-256. The client verifies
that hash before execution; an administrator-gated setting is required to permit hash
override. For MSIX, `SignatureSha256` can bind package-signature metadata. These checks
do not replace Authenticode/MSIX certificate validation or establish reproducible build
provenance.

Source trust is distinct. Pre-indexed sources download `source.msix`/`source2.msix` and
validate package trust before using the embedded SQLite `index.db`; REST sources rely on
HTTPS server identity. The client exposes source trust levels, but marking a source
trusted is local policy, not proof that every vendor payload is signed. Microsoft Store
uses a separate source and certificate-pinning controls.

The default catalog's validation scans payloads and URL reputation before merge. That
raises the moderation bar but does not move payload custody into `winget-pkgs`.

### Publication and discovery

Community submission is a GitHub pull request. Automated jobs validate changed files,
manifest structure, URLs/domains, [catalog policy][policies], catalog consistency,
installer malware scan, dynamic installation, and installer/ARP metadata. The
[moderation guide][moderation] says infrequent contributors receive more manual scrutiny;
moderator approval adds `Moderator-Approved`, and a clean automated validation can then
merge the PR. Scripts are disallowed as community installers even
though the client can install from local manifests.

After merge, the checked-in [`publish-pipeline.yaml`][publish-pipeline] validates commits,
asks an Azure Function to sign the generated source package, publishes the source/index,
and performs post-publication notification/cleanup. The application installer remains at
its `InstallerUrl`. Thus “merge manifest,” “publish signed catalog index,” and “host
payload” are three independent release events.

Discovery comes from configured sources. The default community source and Microsoft
Store are predefined; administrators can add `Microsoft.PreIndexed.Package` endpoints,
and the client implementation also supports REST sources. Internal repositories must
produce a compatible signed pre-indexed source or REST service and separately host or
reference installers; a Git folder of YAML is not itself a client-consumable source.

### Updates and release channels

The catalog stores immutable version directories and WinGet selects the greatest
applicable version. `winget upgrade` refreshes sources, correlates installed applications,
and applies newer manifests. Pins can block all upgrades, gate a version, or require an
explicit upgrade. Downgrade is not the normal upgrade path.

The schema reserves `Channel`, but the pinned 1.12 documentation marks it “not
implemented,” and the reviewed community tree has no active top-level `Channel` values.
The client can preserve and filter channel metadata supplied by another source, as
[`PackageVersionSelection.cpp`][channel-selection] shows, but this is affinity rather
than a public catalog promotion service. Stable, beta, nightly, or major-version streams
therefore normally use separate package identifiers/publisher URLs or source-specific
policy; there is no percentage rollout. “Autoupdate” means automation submits a new
manifest version—WinGet does not infer releases from an upstream URL or rewrite catalog
manifests in the client. `wingetcreate update` and external bots can automate that PR
preparation, but moderation/publication remains explicit.

### Automation and CI

The catalog validation pipeline is unusually deep. Its checked-in stages process PRs,
validate schema/integrity, call URL reputation and domain-policy services, verify catalog
content, scan installers, run installation validation, check metadata correlation, and
label results. Many decisive validators are operated Azure Functions and service-wrapper
binaries fetched during CI, so the repository exposes orchestration and failure labels
rather than a fully reproducible local implementation.

The publish pipeline runs after accepted commits: validate, sign catalog package,
publish/update manifest index, then notify and clean up. Application publishers should
therefore make their Windows artifact immutable first, compute SHA-256, open/update the
manifest PR only after the asset is reachable, and treat catalog acceptance as a later
fan-out job rather than part of artifact construction.

### Supply-chain evidence and reproducibility

Strong evidence includes version-specific URLs, required SHA-256, schema-controlled
metadata, Git review history, URL-domain checks, malware scanning, dynamic install tests,
ARP correlation, and a signed pre-indexed source package. These controls bind reviewed
catalog metadata to downloaded bytes and make accidental upstream replacement visible.

They do not prove how the installer was built. WinGet emits no package SBOM or SLSA
attestation for third-party payloads and cannot make an upstream installer reproducible.
A mutable URL breaks availability until a new hash is approved; compromise of publisher
hosting before manifest creation can pass checksum review; source compromise and
installer-signing compromise remain separate threats.

### Extensibility and UX

The versioned manifest schema absorbs installer diversity while sources decentralize
catalog operation. REST authentication metadata and optional headers support private
services; pre-indexed sources provide a downloadable signed index. The CLI offers one
`search`/`show`/`install`/`upgrade`/`uninstall` vocabulary across sources and installer
technologies.

That uniformity can hide ownership. MSI/MSIX/EXE repair and uninstall belong to their
native systems, community validation does not apply to arbitrary sources, portable
persistence is only unmanaged leftovers, and catalog publication does not mirror the
payload. A release tool integrating WinGet should generate manifests and submit them
only after platform installers are signed and immutable.

## Strengths

- Preserves publisher-hosted, platform-signed installers instead of repackaging them.
- Required per-installer SHA-256 binds catalog review to exact payload bytes.
- Rich schemas normalize switches, scope, dependencies, return codes, and ARP identity.
- Community moderation combines policy, static scanning, dynamic installation, and CI.
- Portable packages receive managed aliases, registration, upgrade, and uninstall.
- Pre-indexed and REST sources provide paths for organizational/internal catalogs.

## Weaknesses

- Catalog success still depends on externally hosted payload availability and immutability.
- Native installer correctness, rollback, repair, and cleanup remain heterogeneous.
- Public catalog channels are reserved but not implemented; promotion, staged rollout, SBOM, and provenance remain external.
- Private source operation requires more than hosting the YAML repository.
- Important default-source validators and publication services are not fully OSS in-tree.
- Hash and malware checks do not establish publisher identity or reproducible builds.

## Key design decisions and trade-offs

| Decision                                        | Rationale                                                 | Trade-off                                                  |
| ----------------------------------------------- | --------------------------------------------------------- | ---------------------------------------------------------- |
| Catalog manifests reference publisher payloads  | Preserve upstream installer/signature and avoid mirroring | Publisher URL availability remains on the critical path    |
| Required SHA-256 per installer                  | Bind review and execution to exact bytes                  | Mutable vanity URLs fail until a new manifest lands        |
| Installer-type-specific switch normalization    | Provide consistent unattended UX                          | Incorrect type/switch metadata can break installs          |
| Delegate native install/uninstall semantics     | Reuse MSI/MSIX/vendor lifecycle engines                   | WinGet cannot guarantee uniform rollback or cleanup        |
| Client-owned portable installation              | Give standalone EXEs package-manager lifecycle            | Persistence and multi-file behavior require extra tracking |
| Moderated PR plus automated validation          | Make a public catalog auditable and safer                 | Publication lags the upstream release                      |
| Signed pre-indexed and REST source protocols    | Support scalable default and private discovery            | A YAML Git repository alone is not a deployable source     |
| Separate identifiers for public release streams | Work around the reserved, unimplemented channel field     | Promotion and staged rollout remain external policy        |

## Sources

- [microsoft/winget-cli at the exact reviewed revision][cli-revision]
- [microsoft/winget-pkgs at the exact reviewed revision][pkgs-revision]
- [`winget-pkgs/README.md`, authoring guide, policies, and moderation guide][pkgs-readme]
- [Manifest 1.12 installer schema documentation][installer-schema]
- [Manifest JSON schema in the client repository][installer-json-schema]
- [`PortableFlow.cpp`][portable-flow] and [portable installer tests][portable-tests]
- [Source command docs][source-doc] and [pre-indexed source implementation][preindexed-source]
- [Catalog validation and publication pipelines][validation-pipeline]
- [Validation failure guide — URL, hash, scan, install, and metadata checks][validation-guide]

Local provenance: `$REPOS/winget-cli` at
`22d5c7d891a30f9d1b52214ba4a6bdbb14183fb1` and `$REPOS/winget-pkgs` at
`84718c8a47370e50d49af08c24776ee8466a0d8d`; inspected schemas, source flows,
portable/source tests, manifest docs and examples, moderation/policy docs, and Azure
pipeline definitions. Claims are `[source-verified]`; Windows execution is not
host-verified.

<!-- References -->

[cli-repo]: https://github.com/microsoft/winget-cli
[pkgs-repo]: https://github.com/microsoft/winget-pkgs
[cli-revision]: https://github.com/microsoft/winget-cli/tree/22d5c7d891a30f9d1b52214ba4a6bdbb14183fb1
[pkgs-revision]: https://github.com/microsoft/winget-pkgs/tree/84718c8a47370e50d49af08c24776ee8466a0d8d
[pkgs-readme]: https://github.com/microsoft/winget-pkgs/blob/84718c8a47370e50d49af08c24776ee8466a0d8d/README.md
[authoring]: https://github.com/microsoft/winget-pkgs/blob/84718c8a47370e50d49af08c24776ee8466a0d8d/doc/Authoring.md
[policies]: https://github.com/microsoft/winget-pkgs/blob/84718c8a47370e50d49af08c24776ee8466a0d8d/doc/Policies.md
[moderation]: https://github.com/microsoft/winget-pkgs/blob/84718c8a47370e50d49af08c24776ee8466a0d8d/doc/Moderation.md
[installer-schema]: https://github.com/microsoft/winget-pkgs/blob/84718c8a47370e50d49af08c24776ee8466a0d8d/doc/manifest/schema/1.12.0/installer.md
[installer-json-schema]: https://github.com/microsoft/winget-cli/blob/22d5c7d891a30f9d1b52214ba4a6bdbb14183fb1/schemas/JSON/manifests/v1.12.0/manifest.installer.1.12.0.json
[portable-flow]: https://github.com/microsoft/winget-cli/blob/22d5c7d891a30f9d1b52214ba4a6bdbb14183fb1/src/AppInstallerCLICore/Workflows/PortableFlow.cpp
[portable-tests]: https://github.com/microsoft/winget-cli/blob/22d5c7d891a30f9d1b52214ba4a6bdbb14183fb1/src/AppInstallerCLITests/PortableInstaller.cpp
[channel-selection]: https://github.com/microsoft/winget-cli/blob/22d5c7d891a30f9d1b52214ba4a6bdbb14183fb1/src/AppInstallerRepositoryCore/PackageVersionSelection.cpp
[source-doc]: https://github.com/microsoft/winget-cli/blob/22d5c7d891a30f9d1b52214ba4a6bdbb14183fb1/doc/windows/package-manager/winget/source.md
[preindexed-source]: https://github.com/microsoft/winget-cli/blob/22d5c7d891a30f9d1b52214ba4a6bdbb14183fb1/src/AppInstallerRepositoryCore/Microsoft/PreIndexedPackageSourceFactory.cpp
[validation-pipeline]: https://github.com/microsoft/winget-pkgs/blob/84718c8a47370e50d49af08c24776ee8466a0d8d/DevOpsPipelineDefinitions/validation-pipeline.yaml
[publish-pipeline]: https://github.com/microsoft/winget-pkgs/blob/84718c8a47370e50d49af08c24776ee8466a0d8d/DevOpsPipelineDefinitions/publish-pipeline.yaml
[validation-guide]: https://github.com/microsoft/winget-pkgs/blob/84718c8a47370e50d49af08c24776ee8466a0d8d/doc/ValidationFailureGuide.md
